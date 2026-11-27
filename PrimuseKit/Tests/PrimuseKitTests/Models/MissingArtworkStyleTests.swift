import XCTest
@testable import PrimuseKit

final class MissingArtworkStyleTests: XCTestCase {
    func testExistingInstallsAndUnknownPreferencesKeepTheOriginalPlaceholder() {
        for stored in [nil, "", "unknown", "standard"] {
            let style = MissingArtworkStyle(storedValue: stored)
            XCTAssertEqual(style, .standard)
            XCTAssertFalse(style.usesAppIcon(forPlaceholderSymbol: "music.note"))
        }
    }

    func testAppIconRequiresOptInAndAppliesOnlyToMusicArtwork() {
        let style = MissingArtworkStyle(storedValue: "appIcon")
        for symbol in ["music.note", "square.stack", "music.note.list"] {
            XCTAssertTrue(style.usesAppIcon(forPlaceholderSymbol: symbol))
        }
        for symbol in ["music.mic", "person.fill", "heart.fill", "radio.fill", "book.closed", "antenna.radiowaves.left.and.right"] {
            XCTAssertFalse(style.usesAppIcon(forPlaceholderSymbol: symbol))
        }
    }
}
