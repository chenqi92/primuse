import XCTest
@testable import PrimuseKit

final class WidgetColorStyleTests: XCTestCase {
    func testUnknownOrMissingValuesFallBackToArtwork() {
        XCTAssertEqual(WidgetColorStyle(storedValue: nil), .artwork)
        XCTAssertEqual(WidgetColorStyle(storedValue: "sepia"), .artwork)
        XCTAssertEqual(WidgetColorStyle(storedValue: "monochrome"), .monochrome)
    }

    func testPublishWritesOnlyWhenTheWidgetsWouldDrawDifferently() throws {
        let suite = "WidgetColorStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(WidgetColorStyleStore.publish(.artwork, to: defaults))
        XCTAssertNil(defaults.string(forKey: WidgetColorStyleStore.key))

        XCTAssertTrue(WidgetColorStyleStore.publish(.monochrome, to: defaults))
        XCTAssertEqual(WidgetColorStyleStore.load(from: defaults), .monochrome)
        XCTAssertFalse(WidgetColorStyleStore.publish(.monochrome, to: defaults))

        XCTAssertTrue(WidgetColorStyleStore.publish(.artwork, to: defaults))
        XCTAssertEqual(WidgetColorStyleStore.load(from: defaults), .artwork)
        XCTAssertFalse(WidgetColorStyleStore.publish(.artwork, to: nil))
    }
}
