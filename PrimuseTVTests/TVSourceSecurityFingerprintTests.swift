#if os(tvOS)
import PrimuseKit
import XCTest
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
}

@MainActor
final class TVCloudDriveSongIdentityTests: XCTestCase {
    func testDropboxRenameKeepsProviderStableSongID() {
        let source = MusicSource(
            id: "dropbox-source",
            name: "Dropbox",
            type: .dropbox
        )
        let lister = TVCloudDriveLister(source: source, credential: nil)
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
