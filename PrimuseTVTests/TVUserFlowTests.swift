#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVUserFlowPolicyTests: XCTestCase {
    func testScanSelectionDropsNestedRootsBeforeNetworkTraversal() {
        XCTAssertEqual(
            TVScanDirectorySelectionPolicy.normalized([
                "/Music/Albums/Live",
                "/Music",
                "/Music/Albums",
                "/Podcasts",
                "/Podcasts/2026/",
            ]),
            ["/Music", "/Podcasts"]
        )
    }

    func testRootScanSelectionDominatesEveryChild() {
        XCTAssertEqual(
            TVScanDirectorySelectionPolicy.normalized(["/Music", "/", "Radio"]),
            ["/"]
        )
    }

    func testTVEditPolicyRejectsProviderSpecificForms() {
        var cloud = MusicSource(name: "Cloud", type: .oneDrive)
        cloud.authType = .oauth
        var s3 = MusicSource(name: "S3", type: .s3)
        s3.authType = .password

        XCTAssertFalse(TVSourceEditPolicy.canEdit(cloud))
        XCTAssertFalse(TVSourceEditPolicy.canEdit(s3))
    }

    func testTVEditPolicyAllowsAddressBackedAPIKeySource() {
        var jellyfin = MusicSource(name: "Jellyfin", type: .jellyfin)
        jellyfin.authType = .apiKey

        XCTAssertTrue(TVSourceEditPolicy.canEdit(jellyfin))
    }

    func testCountFormattingUsesRequestedLocale() {
        XCTAssertEqual(TVFmt.count(12_345, locale: Locale(identifier: "de_DE")), "12.345")
        XCTAssertEqual(TVFmt.count(12_345, locale: Locale(identifier: "en_US")), "12,345")
    }
}
#endif
