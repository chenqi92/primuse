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
        for host in ["localhost", "diskstation.local", "nas.home", "nas.lan", "nas.internal", "10.0.0.8", "172.16.0.8", "172.31.255.8", "192.168.1.8", "169.254.2.3", "127.0.0.1", "::1", "fd00::8", "fe80::8"] {
            XCTAssertTrue(InsecureHTTPHostPolicy.isLocalNetworkHost(host), host)
        }
        for host in ["nas.example.com", "8.8.8.8", "172.15.0.8", "172.32.0.8", "2001:4860:4860::8888"] {
            XCTAssertFalse(InsecureHTTPHostPolicy.isLocalNetworkHost(host), host)
        }
    }

    func testCanonicalEndpointIncludesSchemeAndEffectivePort() throws {
        XCTAssertEqual(
            try XCTUnwrap(NetworkEndpointIdentity(rawValue: "HTTPS://NAS.Example.com/music")).key,
            "https://nas.example.com:443"
        )
        XCTAssertEqual(
            try XCTUnwrap(NetworkEndpointIdentity(rawValue: "http://nas.example.com:5000/music")).key,
            "http://nas.example.com:5000"
        )
        XCTAssertEqual(
            try XCTUnwrap(NetworkEndpointIdentity(rawValue: "https://[fd00::1234]:8443/music")).key,
            "https://[fd00::1234]:8443"
        )
    }

    func testEndpointTrustIdentitySeparatesSchemeAndPort() throws {
        let http = try XCTUnwrap(NetworkEndpointIdentity(rawValue: "http://nas.example.com:5000"))
        let https = try XCTUnwrap(NetworkEndpointIdentity(rawValue: "https://nas.example.com:5000"))
        let otherPort = try XCTUnwrap(NetworkEndpointIdentity(rawValue: "http://nas.example.com:5001"))

        XCTAssertNotEqual(http, https)
        XCTAssertNotEqual(http, otherPort)
    }

    func testRedirectSecurityPreservesEndpointOrConventionalUpgrade() {
        XCTAssertTrue(HTTPRedirectSecurityPolicy.allows(
            from: URL(string: "https://music.example.com:8443/api")!,
            to: URL(string: "https://music.example.com:8443/login")!
        ))
        XCTAssertTrue(HTTPRedirectSecurityPolicy.allows(
            from: URL(string: "http://music.example.com/api")!,
            to: URL(string: "https://music.example.com/login")!
        ))
        XCTAssertFalse(HTTPRedirectSecurityPolicy.allows(
            from: URL(string: "https://music.example.com/api")!,
            to: URL(string: "http://music.example.com/login")!
        ))
        XCTAssertFalse(HTTPRedirectSecurityPolicy.allows(
            from: URL(string: "https://music.example.com:8443/api")!,
            to: URL(string: "https://music.example.com:9443/login")!
        ))
        XCTAssertFalse(HTTPRedirectSecurityPolicy.allows(
            from: URL(string: "https://music.example.com/api")!,
            to: URL(string: "https://other.example.com/login")!
        ))
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
