import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudDriveFormEncodingTests: XCTestCase {
    func testFormBodyPreservesLiteralPlusAndAllPathCharacters() throws {
        let path = "/音乐/R&B + 100% #1 = 完整.flac"
        let token = "refresh+token/with=padding"
        let data = try XCTUnwrap(CloudDriveHelper.formURLEncodedBody([
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "refresh_token", value: token),
        ]))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertTrue(encoded.contains("%2B"))

        var components = URLComponents()
        components.percentEncodedQuery = encoded
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "path" })?.value, path)
        XCTAssertEqual(items.first(where: { $0.name == "refresh_token" })?.value, token)
    }
}

final class MusicScraperFallbackTests: XCTestCase {
    func testSubsonicTransportPathUsesServerMetadataTitle() {
        let song = Song(
            id: "song-hash",
            title: "撕夜",
            artistName: "雷婷",
            fileFormat: .flac,
            filePath: "/songs/VSWDr067Y5zWkIPHJz0VJp.flac",
            sourceID: "navidrome"
        )

        XCTAssertEqual(MusicScraperService.scrapeFallbackTitle(for: song), "撕夜")
    }

    func testCompactCloudIdentifierUsesScannedDisplayTitle() {
        let song = Song(
            id: "song-hash",
            title: "最美的地方",
            artistName: "乐桐",
            fileFormat: .flac,
            filePath: "/opaque/CeMfBqxKq3Svgbx7DSBg6X.flac",
            sourceID: "cloud"
        )

        XCTAssertEqual(MusicScraperService.scrapeFallbackTitle(for: song), "最美的地方")
    }

    func testReadableFilenameRemainsAvailableForStructuredScraping() {
        let song = Song(
            id: "song-hash",
            title: "Track",
            artistName: "Artist",
            fileFormat: .flac,
            filePath: "/music/Artist - Track.flac",
            sourceID: "webdav"
        )

        XCTAssertEqual(
            MusicScraperService.scrapeFallbackTitle(for: song),
            "Artist - Track"
        )
    }
}
