#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVUserFlowPolicyTests: XCTestCase {
    // 电视端选目录与手机、Mac 共用 PrimuseKit 的 SourceDirectorySelectionPolicy。
    func testScanSelectionDropsNestedRootsBeforeNetworkTraversal() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.normalizedSelections([
                "/Music/Albums/Live",
                "/Music",
                "/Music/Albums",
                "/Podcasts",
                "/Podcasts/2026/",
            ], for: .smb),
            ["/Music", "/Podcasts"]
        )
    }

    func testRootScanSelectionDominatesEveryChild() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.normalizedSelections(["/Music", "/", "Radio"], for: .smb),
            ["/"]
        )
    }

    func testFolderAddedUnderSelectedParentReadsAsIncluded() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.selectionState(
                of: "/Music/New",
                in: ["/Music"],
                ancestors: ["/", "/Music"],
                for: .smb
            ),
            .included(by: "/Music")
        )
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.selectionState(of: "/New", in: ["/"], for: .synology),
            .included(by: "/")
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
