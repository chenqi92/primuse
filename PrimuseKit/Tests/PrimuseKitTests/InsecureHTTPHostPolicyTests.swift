import XCTest
@testable import PrimuseKit

final class InsecureHTTPHostPolicyTests: XCTestCase {
    func testNormalizesHostOnlyInputWithoutBroadeningScope() {
        XCTAssertEqual(InsecureHTTPHostPolicy.normalizedHost(" NAS.Example.com. "), "nas.example.com")
        XCTAssertEqual(InsecureHTTPHostPolicy.normalizedHost("http://nas.example.com:5000"), "nas.example.com")
        XCTAssertEqual(InsecureHTTPHostPolicy.normalizedHost("[fd00::1234]:5000"), "fd00::1234")
        XCTAssertNil(InsecureHTTPHostPolicy.normalizedHost("nas.example.com/path"))
    }

    func testRecognizesOnlyLocalAndPrivateAddressRanges() {
        for host in ["localhost", "diskstation.local", "10.0.0.8", "172.16.0.8", "172.31.255.8", "192.168.1.8", "127.0.0.1", "::1", "fd00::8", "fe80::8"] {
            XCTAssertTrue(InsecureHTTPHostPolicy.isLocalNetworkHost(host), host)
        }
        for host in ["nas.example.com", "8.8.8.8", "172.15.0.8", "172.32.0.8", "2001:4860:4860::8888"] {
            XCTAssertFalse(InsecureHTTPHostPolicy.isLocalNetworkHost(host), host)
        }
    }

    func testRequiresTrustOnlyForPublicCleartextHTTP() throws {
        XCTAssertTrue(InsecureHTTPHostPolicy.requiresExplicitTrust(for: try XCTUnwrap(URL(string: "http://nas.example.com:5000"))))
        XCTAssertTrue(InsecureHTTPHostPolicy.requiresExplicitTrust(for: try XCTUnwrap(URL(string: "http://8.8.8.8:5000"))))
        XCTAssertFalse(InsecureHTTPHostPolicy.requiresExplicitTrust(for: try XCTUnwrap(URL(string: "http://192.168.1.8:5000"))))
        XCTAssertFalse(InsecureHTTPHostPolicy.requiresExplicitTrust(for: try XCTUnwrap(URL(string: "https://nas.example.com:5001"))))
    }

    func testTrustMatchIsExact() {
        XCTAssertTrue(InsecureHTTPHostPolicy.matchesExactly(host: "NAS.EXAMPLE.COM", trustedHost: "nas.example.com"))
        XCTAssertFalse(InsecureHTTPHostPolicy.matchesExactly(host: "child.nas.example.com", trustedHost: "nas.example.com"))
        XCTAssertFalse(InsecureHTTPHostPolicy.matchesExactly(host: "evil-nas.example.com", trustedHost: "nas.example.com"))
    }
}
