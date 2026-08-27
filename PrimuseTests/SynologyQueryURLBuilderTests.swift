import Foundation
import XCTest
@testable import Primuse

final class SynologyQueryURLBuilderTests: XCTestCase {
    func testLiteralPlusInFilePathAndSessionIDIsPercentEncoded() throws {
        var components = try XCTUnwrap(
            URLComponents(string: "https://nas.example/webapi/entry.cgi")
        )
        let path = "/music/杨茜 + 小芳 & demo=1.flac"
        let sid = "session+token"
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "_sid", value: sid),
        ]

        let url = try XCTUnwrap(SynologyQueryURLBuilder.url(from: components))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertFalse(url.query?.contains("+") ?? true)

        let decodedItems = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(decodedItems.first(where: { $0.name == "path" })?.value, path)
        XCTAssertEqual(decodedItems.first(where: { $0.name == "_sid" })?.value, sid)
    }

    func testSpacesRemainSpacesInsteadOfFormEncodedPlus() throws {
        let title = "杨茜、江智民、凌澜 _ 弯弯的月亮 + 小芳 + 快乐老家"
        for fileExtension in ["dts", "flac", "wav"] {
            var components = try XCTUnwrap(
                URLComponents(string: "https://nas.example/webapi/entry.cgi")
            )
            components.queryItems = [
                URLQueryItem(
                    name: "path",
                    value: "/music/\(title).\(fileExtension)"
                ),
            ]

            let url = try XCTUnwrap(SynologyQueryURLBuilder.url(from: components))
            XCTAssertTrue(url.absoluteString.contains("%20%2B%20"))
            XCTAssertFalse(url.query?.contains("+") ?? true)
        }
    }
}
