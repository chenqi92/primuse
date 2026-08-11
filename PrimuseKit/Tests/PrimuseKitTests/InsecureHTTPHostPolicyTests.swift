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

    func testRedirectRequestFollowsOnlyAnActualSafeServerRedirect() throws {
        var directRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "http://music.example.com:5000/api/login"))
        )
        directRequest.httpMethod = "POST"
        directRequest.httpBody = Data("credentials".utf8)
        directRequest.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let sameEndpointResponse = try XCTUnwrap(HTTPURLResponse(
            url: directRequest.url!,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/api/v2/login"]
        ))
        let sameEndpoint = try XCTUnwrap(HTTPRedirectRequestPolicy.redirectedRequest(
            from: directRequest,
            response: sameEndpointResponse
        ))
        XCTAssertEqual(sameEndpoint.url?.absoluteString, "http://music.example.com:5000/api/v2/login")
        XCTAssertEqual(sameEndpoint.httpMethod, "POST")
        XCTAssertEqual(sameEndpoint.httpBody, directRequest.httpBody)

        let upgradeRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "http://music.example.com/catalog"))
        )
        let upgradeResponse = try XCTUnwrap(HTTPURLResponse(
            url: upgradeRequest.url!,
            statusCode: 301,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://music.example.com/catalog"]
        ))
        XCTAssertEqual(
            HTTPRedirectRequestPolicy.redirectedRequest(
                from: upgradeRequest,
                response: upgradeResponse
            )?.url?.absoluteString,
            "https://music.example.com/catalog"
        )

        let ordinaryHTTPResponse = try XCTUnwrap(HTTPURLResponse(
            url: upgradeRequest.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://music.example.com/catalog"]
        ))
        XCTAssertNil(HTTPRedirectRequestPolicy.redirectedRequest(
            from: upgradeRequest,
            response: ordinaryHTTPResponse
        ))

        let unsafeResponse = try XCTUnwrap(HTTPURLResponse(
            url: directRequest.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://music.example.com:5001/api/login"]
        ))
        XCTAssertNil(HTTPRedirectRequestPolicy.redirectedRequest(
            from: directRequest,
            response: unsafeResponse
        ))
    }

    func testRedirectRequestMatchesURLSessionMethodSemantics() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://music.example.com/submit"))
        )
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        request.setValue("7", forHTTPHeaderField: "Content-Length")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!,
            statusCode: 303,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/result"]
        ))
        let redirected = try XCTUnwrap(HTTPRedirectRequestPolicy.redirectedRequest(
            from: request,
            response: response
        ))
        XCTAssertEqual(redirected.httpMethod, "GET")
        XCTAssertNil(redirected.httpBody)
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Content-Length"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Content-Type"))
    }

    func testMediaRedirectStripsCredentialsButPreservesRange() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://192.168.0.2:5244/dav/song.mp3"))
        )
        request.httpMethod = "GET"
        request.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 30

        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://cdn.example.net/signed/song.mp3?token=opaque"]
        ))
        let redirected = try XCTUnwrap(HTTPMediaRedirectRequestPolicy.redirectedRequest(
            from: request,
            response: response
        ))

        XCTAssertEqual(redirected.url?.scheme, "https")
        XCTAssertEqual(redirected.url?.host, "cdn.example.net")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=0-262143")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(
            redirected.timeoutInterval,
            HTTPMediaRedirectRetryPolicy.requestTimeout
        )
    }

    func testMediaRedirectUpgradesPublicHTTPCDNFromHTTPSOrigin() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://dav.example.com/song.mp3")))
        request.httpMethod = "GET"
        request.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://cdn.example.net/signed/song.mp3?token=opaque"]
        ))

        let redirected = try XCTUnwrap(HTTPMediaRedirectRequestPolicy.redirectedRequest(
            from: request,
            response: response
        ))

        XCTAssertEqual(redirected.url?.scheme, "https")
        XCTAssertEqual(redirected.url?.host, "cdn.example.net")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=0-4095")
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    }

    func testMediaRedirectRejectsWritesAndHTTPSDowngrades() throws {
        var post = URLRequest(url: try XCTUnwrap(URL(string: "https://dav.example.com/song.mp3")))
        post.httpMethod = "POST"
        let crossHost = try XCTUnwrap(HTTPURLResponse(
            url: post.url!,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://cdn.example.net/song.mp3"]
        ))
        XCTAssertNil(HTTPMediaRedirectRequestPolicy.redirectedRequest(from: post, response: crossHost))

        var get = post
        get.httpMethod = "GET"
        let downgrade = try XCTUnwrap(HTTPURLResponse(
            url: get.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://192.168.0.2/song.mp3"]
        ))
        XCTAssertNil(HTTPMediaRedirectRequestPolicy.redirectedRequest(from: get, response: downgrade))
    }

    func testMediaRedirectRetryPolicyOnlyRetriesTransientFailures() {
        XCTAssertTrue(HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: 403))
        XCTAssertTrue(HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: 429))
        XCTAssertTrue(HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: 503))
        XCTAssertFalse(HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: 206))
        XCTAssertTrue(HTTPMediaRedirectRetryPolicy.isRetryable(error: URLError(.timedOut)))
        XCTAssertTrue(HTTPMediaRedirectRetryPolicy.isRetryable(error: URLError(.networkConnectionLost)))
        XCTAssertFalse(HTTPMediaRedirectRetryPolicy.isRetryable(error: URLError(.cancelled)))
        XCTAssertFalse(HTTPMediaRedirectRetryPolicy.isRetryable(error: URLError(.secureConnectionFailed)))
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
