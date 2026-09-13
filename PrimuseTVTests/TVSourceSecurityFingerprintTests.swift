#if os(tvOS)
import Foundation
import XCTest
@testable import PrimuseKit
@testable import PrimuseTV

final class TVSourceSecurityFingerprintTests: XCTestCase {
    func testTVTargetUsesSharedSecurityFingerprintPolicy() {
        let source = MusicSource(
            id: "tv-security-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            port: 4_533,
            useSsl: true,
            username: "listener"
        )

        XCTAssertEqual(
            MusicSourceSecurityRevision.scopedFingerprint(
                for: source,
                revision: 11
            ),
            MusicSourceSecurityScopeFingerprint.make(
                for: source,
                revision: 11
            )
        )
        XCTAssertNotEqual(
            MusicSourceSecurityRevision.scopedFingerprint(
                for: source,
                revision: 11
            ),
            MusicSourceSecurityRevision.scopedFingerprint(
                for: source,
                revision: 12
            )
        )
    }

    func testResolverSessionHandlesTaskLevelAuthenticationChallenges() throws {
        let session = StreamResolverSessionFactory.make(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let delegate = try XCTUnwrap(session.delegate as? NSObject)
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString(
            "URLSession:task:didReceiveChallenge:completionHandler:"
        )))
    }

    func testSynologyTrustedDeviceIDAcceptsDSMResponseKeys() {
        XCTAssertEqual(
            SynologyStreamResolver.trustedDeviceID(from: ["did": "legacy-token"]),
            "legacy-token"
        )
        XCTAssertEqual(
            SynologyStreamResolver.trustedDeviceID(from: ["device_id": "device-token"]),
            "device-token"
        )
        XCTAssertEqual(
            SynologyStreamResolver.trustedDeviceID(from: ["did": "", "device_id": "fallback-token"]),
            "fallback-token"
        )
        XCTAssertNil(SynologyStreamResolver.trustedDeviceID(from: [:]))
    }
}

@MainActor
final class TVCloudDriveSongIdentityTests: XCTestCase {
    func testDropboxRenameKeepsProviderStableSongID() throws {
        let source = MusicSource(
            id: "dropbox-source",
            name: "Dropbox",
            type: .dropbox
        )
        let lister = try XCTUnwrap(TVSourceScanner().makeLister(source: source, credential: nil))
        XCTAssertTrue(lister.usesStableProviderSongIdentity)

        let beforeRename = TVSourceScanner.makeSong(
            entry: TVDirEntry(
                name: "Before.flac",
                isDir: false,
                size: 4_096,
                path: "/Music/Before.flac",
                providerID: "id:stable-track"
            ),
            source: source,
            usesStableProviderIdentity: lister.usesStableProviderSongIdentity
        )
        let afterRename = TVSourceScanner.makeSong(
            entry: TVDirEntry(
                name: "After.flac",
                isDir: false,
                size: 4_096,
                path: "/Renamed/After.flac",
                providerID: "id:stable-track"
            ),
            source: source,
            usesStableProviderIdentity: lister.usesStableProviderSongIdentity
        )

        XCTAssertEqual(beforeRename.id, afterRename.id)
        XCTAssertEqual(beforeRename.id.count, 32)
    }
}
#endif
