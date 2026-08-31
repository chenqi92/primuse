import XCTest
import SwiftUI
@testable import Primuse

final class LibraryDisplayConfigurationTests: XCTestCase {
    func testFreshLibraryUsesRecommendationFirst() {
        XCTAssertEqual(
            LibraryDisplayConfiguration.decodeSectionOrder(""),
            LibraryDisplayConfiguration.defaultSectionOrder
        )
        XCTAssertEqual(
            LibraryDisplayConfiguration.defaultSectionOrder.first,
            .recommendations
        )
    }

    func testExistingCustomOrderKeepsItsShapeWhenRecommendationsAreIntroduced() {
        let oldOrder: [LibrarySection] = [.albums, .songs, .artists, .playlists, .radio]
        let rawValue = LibraryDisplayConfiguration.encodeSectionOrder(oldOrder)

        XCTAssertEqual(
            LibraryDisplayConfiguration.decodeSectionOrder(rawValue),
            [.recommendations, .albums, .songs, .artists, .playlists, .radio]
        )
    }

    func testStoredSectionsRemainUnique() {
        let rawValue = LibraryDisplayConfiguration.encodeSectionOrder([
            .songs, .songs, .recommendations, .radio,
        ])
        let decoded = LibraryDisplayConfiguration.decodeSectionOrder(rawValue)

        XCTAssertEqual(Set(decoded), Set(LibrarySection.allCases))
        XCTAssertEqual(decoded.count, LibrarySection.allCases.count)
    }

    func testSongInfoSupportsMediumAndLargeDetents() {
        XCTAssertEqual(
            SongInfoPresentationConfiguration.detents,
            Set([PresentationDetent.medium, .large])
        )
    }

    func testNavigationModeDefaultsToStandardForMissingOrInvalidValues() {
        XCTAssertEqual(AppNavigationMode.resolve(""), .standard)
        XCTAssertEqual(AppNavigationMode.resolve("future-mode"), .standard)
        XCTAssertEqual(AppNavigationMode.resolve(AppNavigationMode.minimal.rawValue), .minimal)
    }

    func testStandardRootLayoutsRemainWidthAdaptive() {
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .standard, usesRegularWidth: false),
            .standardTabs
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .standard, usesRegularWidth: true),
            .standardSidebar
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .minimal, usesRegularWidth: false),
            .minimal
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .minimal, usesRegularWidth: true),
            .minimal
        )
    }

    func testMinimalLibraryPagesFollowVisibleSectionOrder() {
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(
                visibleSections: [.songs, .albums, .radio]
            ),
            [
                .library,
                .librarySection(.songs),
                .librarySection(.albums),
                .librarySection(.radio),
            ]
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(visibleSections: []),
            [.library]
        )
    }

    func testMinimalSelectionMirrorsExistingRootTabAndLibrarySection() {
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: .artists
            ),
            .librarySection(.artists)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: nil
            ),
            .library
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 2,
                activeLibrarySection: .songs
            ),
            .search
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 99,
                activeLibrarySection: nil
            ),
            .home
        )
    }

    func testMinimalDeepLinksSelectTheirLibraryCategory() {
        XCTAssertNil(MinimalNavigationPolicy.section(for: .root))
        XCTAssertEqual(
            MinimalNavigationPolicy.section(for: .section(.radio)),
            .radio
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.section(for: .song("song-id")),
            .songs
        )
    }
}
