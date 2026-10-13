#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVSourceHTTPFailureTests: XCTestCase {
    func testTokenRefreshHonorsSharedCooldownWithoutReplay() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TVTokenQuotaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        TVTokenQuotaProtocol.lock.withLock { TVTokenQuotaProtocol.requests = 0 }
        let requests = OAuthTokenRequests(registry: RequestQuotaRegistry())
        for _ in 0..<2 {
            do {
                _ = try await CloudDriveHelper(sourceID: UUID().uuidString).tokenRequest(
                    URLRequest(url: URL(string: "https://oauth.example/token")!), clientID: "fixture",
                    session: session, requests: requests)
                XCTFail("Expected token endpoint cooldown")
            } catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 429)
                XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590)
            }
        }
        XCTAssertEqual(TVTokenQuotaProtocol.lock.withLock { TVTokenQuotaProtocol.requests }, 1)
    }

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
private final class TVTokenQuotaProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "oauth.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "3600"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
