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
}
