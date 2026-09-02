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
#endif
