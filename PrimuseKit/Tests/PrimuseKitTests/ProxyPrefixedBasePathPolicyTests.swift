import Foundation
import Testing
@testable import PrimuseKit

struct ProxyPrefixedBasePathPolicyTests {
    // MARK: - 基址组装

    /// 与 `SubsonicStreamResolver.makeBaseURL` /
    /// `MediaServerStreamResolver.baseURL` 逐行一致的组装方式。
    private func baseURL(
        host: String,
        port: Int? = nil,
        useSsl: Bool = true,
        basePath: String? = nil
    ) -> URL? {
        let address = ProxyPrefixedBasePathPolicy.splitAddress(host)
        let split = NetworkHostAuthority.splitHostAndPort(address.authority)
        guard let authority = NetworkHostAuthority.authority(
            host: split.host,
            port: split.port ?? port
        ) else { return nil }
        return ProxyPrefixedBasePathPolicy.baseURL(
            scheme: address.scheme ?? (useSsl ? "https" : "http"),
            authority: authority,
            hostPath: address.pathPrefix,
            basePath: basePath
        )
    }

    /// 改动前的实现,原样抄过来当基准。普通 base path 的输出必须与它逐字节
    /// 相同 —— basePath 参与目录快照与歌曲身份,改写等于让老用户重扫。
    private func legacyBaseURL(
        host: String,
        port: Int? = nil,
        useSsl: Bool = true,
        basePath: String? = nil
    ) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let r = h.range(of: "://") {
            scheme = String(h[..<r.lowerBound]).lowercased()
            h = String(h[r.upperBound...])
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        let split = NetworkHostAuthority.splitHostAndPort(h)
        guard let hostPort = NetworkHostAuthority.authority(
            host: split.host,
            port: split.port ?? port
        ) else { return nil }
        guard var url = URL(string: "\(scheme)://\(hostPort)") else { return nil }
        if let bp = basePath?.trimmingCharacters(in: .whitespacesAndNewlines), !bp.isEmpty {
            for component in bp.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }
        return url
    }

    // MARK: - 地址切分

    @Test func splitsPlainHost() {
        let address = ProxyPrefixedBasePathPolicy.splitAddress(" nav.example.com ")
        #expect(address.scheme == nil)
        #expect(address.authority == "nav.example.com")
        #expect(address.pathPrefix == "")
    }

    @Test func splitsHostWithPortAndScheme() {
        let bare = ProxyPrefixedBasePathPolicy.splitAddress("nav.example.com:4533")
        #expect(bare.scheme == nil)
        #expect(bare.authority == "nav.example.com:4533")

        let schemed = ProxyPrefixedBasePathPolicy.splitAddress("HTTP://nav.example.com:4533")
        #expect(schemed.scheme == "http")
        #expect(schemed.authority == "nav.example.com:4533")
        #expect(schemed.pathPrefix == "")
    }

    @Test func splitsIPv6Literals() {
        let bare = ProxyPrefixedBasePathPolicy.splitAddress("fd00::1")
        #expect(bare.authority == "fd00::1")
        #expect(bare.pathPrefix == "")

        let bracketed = ProxyPrefixedBasePathPolicy.splitAddress("[fd00::1]:5005")
        #expect(bracketed.authority == "[fd00::1]:5005")

        let schemed = ProxyPrefixedBasePathPolicy.splitAddress("https://[fd00::1]:5005/music")
        #expect(schemed.scheme == "https")
        #expect(schemed.authority == "[fd00::1]:5005")
        #expect(schemed.pathPrefix == "/music")
    }

    @Test func keepsNestedURLOutOfTheScheme() {
        // 第一个 `://` 属于内层地址,外层主机没有 scheme。
        let address = ProxyPrefixedBasePathPolicy.splitAddress(
            "proxy.example.com/https://nav.example.com:4533"
        )
        #expect(address.scheme == nil)
        #expect(address.authority == "proxy.example.com")
        #expect(address.pathPrefix == "/https://nav.example.com:4533")
    }

    // MARK: - 普通 base path:逐字节不变

    @Test(arguments: [
        "/music", "music", "music/", "/music/", "navidrome", "a/b/c",
        "my music", "音乐", "a%20b", "a%b", "a+b", "a&b", "a?b", "a#b",
        "a//b", "/", "", "   ",
    ])
    func ordinaryBasePathIsByteIdentical(_ basePath: String) {
        for host in ["nav.example.com", "https://nav.example.com", "fd00::1",
                     "[fd00::1]:5005", "nav.example.com:4533"] {
            for port in [nil, 4_533] as [Int?] {
                #expect(
                    baseURL(host: host, port: port, basePath: basePath)?.absoluteString
                        == legacyBaseURL(host: host, port: port, basePath: basePath)?.absoluteString
                )
            }
        }
    }

    @Test func ordinaryBasePathKeepsKnownOutput() {
        #expect(
            baseURL(host: "nav.example.com", port: 4_533, basePath: "/music/")?.absoluteString
                == "https://nav.example.com:4533/music"
        )
        // 首段里的冒号照旧转义 —— appendPathComponent 一直是这么拼的。
        #expect(
            baseURL(host: "nav.example.com", basePath: "foo:bar")?.absoluteString
                == "https://nav.example.com/foo%3Abar"
        )
        #expect(
            baseURL(host: "nav.example.com", basePath: "x:y/z:w")?.absoluteString
                == "https://nav.example.com/x%3Ay/z:w"
        )
        #expect(
            baseURL(host: "nav.example.com", basePath: "my music")?.absoluteString
                == "https://nav.example.com/my%20music"
        )
        #expect(
            baseURL(host: "fd00::1", port: 5_005, useSsl: false, basePath: "music")?
                .absoluteString == "http://[fd00::1]:5005/music"
        )
    }

    @Test func emptyBasePathLeavesBaseUntouched() {
        #expect(baseURL(host: "nav.example.com")?.absoluteString == "https://nav.example.com")
        #expect(
            baseURL(host: "nav.example.com", basePath: "/")?.absoluteString
                == "https://nav.example.com"
        )
    }

    // MARK: - 反代前缀

    @Test func keepsEmbeddedURLVerbatim() {
        #expect(
            baseURL(
                host: "proxy.example.com",
                port: 443,
                basePath: "https://nav.example.com:4533"
            )?.absoluteString == "https://proxy.example.com:443/https://nav.example.com:4533"
        )
    }

    @Test func keepsEmbeddedURLWithTrailingSlashAndSubPath() {
        #expect(
            baseURL(host: "proxy.example.com", basePath: "/https://nav.example.com:4533/")?
                .absoluteString == "https://proxy.example.com/https://nav.example.com:4533"
        )
        #expect(
            baseURL(host: "proxy.example.com", basePath: "https://nav.example.com:4533/music")?
                .absoluteString == "https://proxy.example.com/https://nav.example.com:4533/music"
        )
    }

    @Test func keepsInnerPlainHTTPAddress() {
        // 内层只是路径文本,外层仍是 https —— 明文判定看的是外层主机。
        let url = baseURL(host: "proxy.example.com", basePath: "http://192.168.1.9:4533")
        #expect(url?.absoluteString == "https://proxy.example.com/http://192.168.1.9:4533")
        #expect(url?.scheme == "https")
        #expect(url?.host == "proxy.example.com")
    }

    @Test func plainHTTPTrustFollowsTheOuterProxyHost() throws {
        // 内层的 http:// 只是路径文本:明文 HTTP / ATS / 证书信任一律看外层主机。
        let secureProxy = try #require(
            baseURL(host: "proxy.example.com", basePath: "http://192.168.1.9:4533")
        )
        #expect(InsecureHTTPHostPolicy.requiresExplicitTrust(for: secureProxy) == false)
        #expect(NetworkEndpointIdentity(url: secureProxy)?.key == "https://proxy.example.com:443")

        let plainProxy = try #require(
            baseURL(
                host: "proxy.example.com",
                useSsl: false,
                basePath: "https://nav.example.com:4533"
            )
        )
        #expect(InsecureHTTPHostPolicy.requiresExplicitTrust(for: plainProxy))
    }

    @Test func movesPastedAddressPathIntoThePrefix() {
        #expect(
            baseURL(host: "https://proxy.example.com/https://nav.example.com:4533")?
                .absoluteString == "https://proxy.example.com/https://nav.example.com:4533"
        )
        // 地址自带路径时,普通前缀同样要保留而不是被截掉。
        #expect(
            baseURL(host: "https://nav.example.com/music", port: 4_533)?.absoluteString
                == "https://nav.example.com:4533/music"
        )
        // 地址里的路径与单独填的前缀会拼在一起。
        #expect(
            baseURL(
                host: "https://proxy.example.com/https://nav.example.com:4533",
                basePath: "music"
            )?.absoluteString
                == "https://proxy.example.com/https://nav.example.com:4533/music"
        )
    }

    // MARK: - 接 API 路径

    @Test func appendsAPIPathWithoutCollapsingThePrefix() throws {
        let base = try #require(
            baseURL(host: "proxy.example.com", basePath: "https://nav.example.com:4533")
        )
        let url = ProxyPrefixedBasePathPolicy.appending("rest/ping.view", to: base)
        #expect(
            url.absoluteString
                == "https://proxy.example.com/https://nav.example.com:4533/rest/ping.view"
        )
    }

    @Test func appendsAPIPathAndQueryToTheFinalURL() throws {
        let base = try #require(
            baseURL(host: "proxy.example.com", basePath: "https://nav.example.com:4533")
        )
        let url = ProxyPrefixedBasePathPolicy.appending("rest/ping.view", to: base)
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems = [
            URLQueryItem(name: "u", value: "a"),
            URLQueryItem(name: "p", value: "b"),
        ]
        #expect(
            FormSafeQueryURLBuilder.url(from: components)?.absoluteString
                == "https://proxy.example.com/https://nav.example.com:4533/rest/ping.view?u=a&p=b"
        )
    }

    @Test func apiPathAppendIsByteIdenticalWithoutAPrefix() throws {
        for basePath in [nil, "/music", "my music"] as [String?] {
            let base = try #require(baseURL(host: "nav.example.com", basePath: basePath))
            var legacy = base
            legacy.appendPathComponent("rest")
            legacy.appendPathComponent("ping.view")
            let resolved = ProxyPrefixedBasePathPolicy.appending("rest/ping.view", to: base)
            #expect(resolved.absoluteString == legacy.absoluteString)
        }
    }

    // MARK: - 端口

    @Test func derivesProxyPortOnlyForPastedEmbeddedURLs() {
        let pasted = ProxyPrefixedBasePathPolicy.splitAddress(
            "https://proxy.example.com/https://nav.example.com:4533"
        )
        #expect(ProxyPrefixedBasePathPolicy.embeddedURLProxyPort(for: pasted) == 443)

        let plainPasted = ProxyPrefixedBasePathPolicy.splitAddress(
            "http://proxy.example.com/https://nav.example.com:4533"
        )
        #expect(ProxyPrefixedBasePathPolicy.embeddedURLProxyPort(for: plainPasted) == 80)

        // 地址自己写了端口就听用户的。
        let explicit = ProxyPrefixedBasePathPolicy.splitAddress(
            "https://proxy.example.com:8443/https://nav.example.com:4533"
        )
        #expect(ProxyPrefixedBasePathPolicy.embeddedURLProxyPort(for: explicit) == nil)

        // 普通地址一律不动,免得把 Navidrome 的 4533 顶成 443。
        for address in ["https://nav.example.com", "https://nav.example.com/music",
                        "nav.example.com"] {
            #expect(
                ProxyPrefixedBasePathPolicy.embeddedURLProxyPort(
                    for: ProxyPrefixedBasePathPolicy.splitAddress(address)
                ) == nil
            )
        }
    }
}
