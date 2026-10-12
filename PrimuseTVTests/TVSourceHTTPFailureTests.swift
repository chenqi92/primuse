#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVSourceHTTPFailureTests: XCTestCase {
    func testHTTPFailuresUseTheSharedLocalizedSourcePresentation() {
        for status in [200, 403, 429, 503] {
            let failure = HTTPResponseFailure(statusCode: status, retryAfter: 2.2, isRateLimited: status == 200)
            XCTAssertEqual(TVSourceErrorText.message(error: failure), PMString("request.rateLimited.wait", 3.0))
            XCTAssertFalse(TVSourceErrorText.isSilent(failure))
        }
        for status in [401, 403] {
            XCTAssertEqual(TVSourceErrorText.message(error: HTTPResponseFailure(statusCode: status)), PMString("ext.tv.test.authFailed"))
        }
        XCTAssertEqual(TVSourceErrorText.message(error: HTTPResponseFailure(statusCode: 500)), PMString("ext.tv.playback.httpError", 500))
        XCTAssertTrue(TVSourceErrorText.isSilent(CancellationError()))
    }
}
#endif
