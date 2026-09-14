import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 音乐源地址栏里的 IPv6 写法。`NetworkURLBuilder` 是 WebDAV / FTP / S3 /
/// Jellyfin / Subsonic / 群晖 / 绿联 以及目录浏览共用的基址拼接入口，这里锁住
/// 各种 IPv6 形态都能拼出可用的 URL：以前 `[fd00::1]:5005` 与带 zone 的
/// `fe80::1%en0` 会被直接写进 `URLComponents.percentEncodedHost`，Foundation
/// 判定字符非法后整个进程断言退出，目录自然加载不出来。
final class NetworkURLBuilderIPv6Tests: XCTestCase {
    private func url(
        _ host: String,
        scheme: String = "http",
        port: Int? = nil,
        path: String? = nil,
        forceScheme: Bool = false
    ) -> String? {
        NetworkURLBuilder.makeURL(
            host: host,
            defaultScheme: scheme,
            port: port,
            path: path,
            forceScheme: forceScheme
        )?.absoluteString
    }

    func testBracketedIPv6KeepsItsEmbeddedPort() {
        XCTAssertEqual(
            url("[fd00::1]:5005", port: 80, path: "/dav"),
            "http://[fd00::1]:5005/dav"
        )
        XCTAssertEqual(url("[fd00::1]:5005"), "http://[fd00::1]:5005")
    }

    func testIPv6LiteralsAcceptEveryWrittenForm() {
        XCTAssertEqual(url("fd00::1", port: 5005, path: "/dav"), "http://[fd00::1]:5005/dav")
        XCTAssertEqual(url("[fd00::1]", port: 5005, path: "/dav"), "http://[fd00::1]:5005/dav")
        XCTAssertEqual(url("::1", port: 5005), "http://[::1]:5005")
        XCTAssertEqual(url("[fd00::1]", scheme: "https", path: "/dav"), "https://[fd00::1]/dav")
    }

    func testLinkLocalZoneIsPercentEncoded() {
        XCTAssertEqual(url("fe80::1%en0", port: 5005), "http://[fe80::1%25en0]:5005")
    }

    func testIPv6URLKeepsItsOwnPathAndHonoursForcedScheme() {
        XCTAssertEqual(
            url("http://[fd00::1]:5005/music", path: "/dav"),
            "http://[fd00::1]:5005/music"
        )
        XCTAssertEqual(
            url("http://[fd00::1]:5005", scheme: "https", forceScheme: true),
            "https://[fd00::1]:5005"
        )
    }

    /// 裸地址带路径时以表单里的 basePath 为准，与主机名分支保持一致。
    func testIPv6AddressPathYieldsToTheConfiguredBasePath() {
        XCTAssertEqual(url("[fd00::1]:5005/music", path: "/dav"), "http://[fd00::1]:5005/dav")
    }

    func testHostnameAndIPv4BehaviourIsUnchanged() {
        XCTAssertEqual(url("nas.example.com", port: 5005, path: "/dav"), "http://nas.example.com:5005/dav")
        XCTAssertEqual(url("nas.example.com:5005", port: 80, path: "/dav"), "http://nas.example.com:5005/dav")
        XCTAssertEqual(url("192.168.1.10", port: 5005, path: "/dav"), "http://192.168.1.10:5005/dav")
        XCTAssertEqual(url("nas.local.", port: 5005), "http://nas.local:5005")
        XCTAssertEqual(
            url("https://nas.example.com/music", port: 443, path: "/dav"),
            "https://nas.example.com:443/music"
        )
        XCTAssertNil(url("   ", port: 80))
    }
}
