import Foundation
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
