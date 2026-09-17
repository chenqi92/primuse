import Foundation
import Testing
@testable import PrimuseKit

@Suite("WebDAV path policy")
struct WebDAVPathPolicyTests {
    @Test("Direct WebDAV roots map hrefs to source-relative paths")
    func directRoot() {
        let policy = WebDAVPathPolicy(basePath: "/dav/")

        #expect(policy.sourcePath(forServerPath: "/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/dav/Albums/song.flac") == "/Albums/song.flac")
        #expect(policy.sourcePath(forServerPath: "/dav-other/song.flac") == nil)
    }

    @Test("Reverse proxy roots accept only the configured root or upstream leaf")
    func reverseProxyRoot() {
        let policy = WebDAVPathPolicy(basePath: "/qa-wan/openlist/dav/")

        #expect(policy.sourcePath(forServerPath: "/qa-wan/openlist/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/qa-wan/openlist/dav/Albums") == "/Albums")
        #expect(policy.sourcePath(forServerPath: "/openlist/dav/Albums") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/dav/%E5%B9%B4%E8%BD%BB%E7%9C%9F%E5%A5%BD.mp3") == "/年轻真好.mp3")
    }

    @Test("Root collisions and parent traversal stay outside the source")
    func rejectsUnsafePaths() {
        let policy = WebDAVPathPolicy(basePath: "/qa-wan/openlist/dav")

        #expect(policy.sourcePath(forServerPath: "/other/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav-other/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/wan/openlist/dav/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav/../secret.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "dav/song.mp3") == nil)
    }

    @Test("Server root paths stay unchanged for root WebDAV sources")
    func rootSource() {
        let policy = WebDAVPathPolicy(basePath: nil)

        #expect(policy.sourcePath(forServerPath: "/") == "/")
        #expect(policy.sourcePath(forServerPath: "/Music/song.mp3") == "/Music/song.mp3")
    }

    @Test("FilesProvider callbacks remain source-relative for root and prefixed servers")
    func providerRelativePaths() {
        let rootPolicy = WebDAVPathPolicy(basePath: nil)
        let prefixedPolicy = WebDAVPathPolicy(basePath: "/dav")

        #expect(rootPolicy.sourcePath(forProviderPath: "/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/dav/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/%E5%B9%B4%E8%BD%BB%E7%9C%9F%E5%A5%BD.mp3")
            == "/年轻真好.mp3")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/Albums/../secret.mp3") == nil)
        #expect(prefixedPolicy.sourcePath(forProviderPath: "Albums/song.flac")
            == "/Albums/song.flac")
    }

    @Test("Response hrefs resolve to the same path whatever origin they name")
    func hrefIgnoresResponseOrigin() {
        let baseURL = URL(string: "https://dav.example.com/dav/")!
        let policy = WebDAVPathPolicy(basePath: baseURL.path)
        let expected = "/Music/song.mp3"

        #expect(policy.sourcePath(forHref: "/dav/Music/song.mp3", baseURL: baseURL) == expected)
        #expect(policy.sourcePath(
            forHref: "https://dav.example.com/dav/Music/song.mp3",
            baseURL: baseURL
        ) == expected)
        #expect(policy.sourcePath(
            forHref: "https://dav.example.com:8443/dav/Music/song.mp3",
            baseURL: baseURL
        ) == expected)
        #expect(policy.sourcePath(
            forHref: "http://dav.example.com/dav/Music/song.mp3",
            baseURL: baseURL
        ) == expected)
        #expect(policy.sourcePath(
            forHref: "http://webdav:8080/dav/Music/song.mp3",
            baseURL: baseURL
        ) == expected)
        #expect(policy.sourcePath(forHref: "Music/song.mp3", baseURL: baseURL) == expected)
    }

    @Test("Upstream origins behind a proxy or tunnel still land inside the source")
    func hrefAcceptsUpstreamOrigins() {
        let publicURL = URL(string: "https://dav.example.com/dav/")!
        let publicPolicy = WebDAVPathPolicy(basePath: publicURL.path)

        #expect(publicPolicy.sourcePath(
            forHref: "http://192.168.1.10:5005/dav/Music/song.mp3",
            baseURL: publicURL
        ) == "/Music/song.mp3")
        #expect(publicPolicy.sourcePath(
            forHref: "http://[fd00:1234::10]:5005/dav/Music/song.mp3",
            baseURL: publicURL
        ) == "/Music/song.mp3")

        let proxyURL = URL(string: "https://dav.example.com/qa-wan/openlist/dav/")!
        let proxyPolicy = WebDAVPathPolicy(basePath: proxyURL.path)
        #expect(proxyPolicy.sourcePath(
            forHref: "http://192.168.1.10:5244/dav/Albums",
            baseURL: proxyURL
        ) == "/Albums")

        let literalURL = URL(string: "http://[fd00:1234::10]:5005/dav/")!
        let literalPolicy = WebDAVPathPolicy(basePath: literalURL.path)
        #expect(literalPolicy.sourcePath(
            forHref: "/dav/Music/song.mp3",
            baseURL: literalURL
        ) == "/Music/song.mp3")
        #expect(literalPolicy.sourcePath(
            forHref: "https://dav.example.com/dav/Music/song.mp3",
            baseURL: literalURL
        ) == "/Music/song.mp3")

        let rootURL = URL(string: "https://dav.example.com/")!
        let rootPolicy = WebDAVPathPolicy(basePath: rootURL.path)
        #expect(rootPolicy.sourcePath(
            forHref: "http://webdav:8080/Music/song.mp3",
            baseURL: rootURL
        ) == "/Music/song.mp3")
    }

    @Test("Href escaping survives spaces, percent escapes and non-ASCII names")
    func hrefKeepsEscapedNames() {
        let baseURL = URL(string: "https://dav.example.com/dav/")!
        let policy = WebDAVPathPolicy(basePath: baseURL.path)

        #expect(policy.sourcePath(forHref: "/dav/My Songs/a b.mp3", baseURL: baseURL)
            == "/My Songs/a b.mp3")
        #expect(policy.sourcePath(forHref: "/dav/My%20Songs/a%20b.mp3", baseURL: baseURL)
            == "/My Songs/a b.mp3")
        #expect(policy.sourcePath(
            forHref: "http://192.168.1.10:5005/dav/My Songs/a b.mp3",
            baseURL: baseURL
        ) == "/My Songs/a b.mp3")
        #expect(policy.sourcePath(
            forHref: "/dav/%E5%B9%B4%E8%BD%BB%E7%9C%9F%E5%A5%BD.mp3",
            baseURL: baseURL
        ) == "/年轻真好.mp3")
        #expect(policy.sourcePath(
            forHref: "http://192.168.1.10:5005/dav/年轻真好.mp3",
            baseURL: baseURL
        ) == "/年轻真好.mp3")
    }

    @Test("Hrefs outside the configured root stay rejected regardless of origin")
    func hrefRejectsOutOfScopePaths() {
        let baseURL = URL(string: "https://dav.example.com/dav/")!
        let policy = WebDAVPathPolicy(basePath: baseURL.path)

        #expect(policy.sourcePath(forHref: "/other/song.mp3", baseURL: baseURL) == nil)
        #expect(policy.sourcePath(
            forHref: "http://192.168.1.10:5005/other/song.mp3",
            baseURL: baseURL
        ) == nil)
        #expect(policy.sourcePath(forHref: "/dav-other/song.mp3", baseURL: baseURL) == nil)
        #expect(policy.sourcePath(forHref: "/dav/../secret.mp3", baseURL: baseURL) == nil)
        #expect(policy.sourcePath(forHref: "/dav/%2E%2E/secret.mp3", baseURL: baseURL) == nil)
        #expect(policy.sourcePath(
            forHref: "http://192.168.1.10:5005/dav/%2E%2E/secret.mp3",
            baseURL: baseURL
        ) == nil)
    }

    @Test("The requested directory's own entry resolves to that directory")
    func hrefResolvesRequestedDirectory() {
        let baseURL = URL(string: "https://dav.example.com/dav/")!
        let policy = WebDAVPathPolicy(basePath: baseURL.path)

        #expect(policy.sourcePath(forHref: "/dav/", baseURL: baseURL) == "/")
        #expect(policy.sourcePath(forHref: "/dav", baseURL: baseURL) == "/")
        #expect(policy.sourcePath(forHref: "http://192.168.1.10:5005/dav/", baseURL: baseURL) == "/")
        #expect(policy.sourcePath(forHref: "/dav/Albums/", baseURL: baseURL) == "/Albums")
        #expect(policy.sourcePath(
            forHref: "http://192.168.1.10:5005/dav/Albums/",
            baseURL: baseURL
        ) == "/Albums")

        let proxyURL = URL(string: "https://dav.example.com/qa-wan/openlist/dav/")!
        let proxyPolicy = WebDAVPathPolicy(basePath: proxyURL.path)
        #expect(proxyPolicy.sourcePath(
            forHref: "http://192.168.1.10:5244/dav/",
            baseURL: proxyURL
        ) == "/")

        let rootURL = URL(string: "https://dav.example.com/")!
        let rootPolicy = WebDAVPathPolicy(basePath: rootURL.path)
        #expect(rootPolicy.sourcePath(forHref: "/", baseURL: rootURL) == "/")
        #expect(rootPolicy.sourcePath(forHref: "http://webdav:8080/", baseURL: rootURL) == "/")
    }
}
